import { NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { DatabaseService } from '../../config/database/database.service';
import { CategoriesService } from './categories.service';
import { CategoryResponseDto } from './dto';

describe('CategoriesService', () => {
  let service: CategoriesService;
  let databaseService: DatabaseService;

  const mockMenuId = 'menu-uuid-1';
  const mockRestaurantId = 'res-uuid-1';

  const mockCategory: CategoryResponseDto = {
    id: 'cat-entradas-1',
    restaurant_id: mockRestaurantId,
    menu_id: mockMenuId,
    name: 'Entradas',
    description: null,
    type: 'entrada',
    display_order: 0,
    is_active: true,
    created_at: '2026-02-28T03:28:24.097231+00:00',
    updated_at: '2026-02-28T03:28:24.097231+00:00',
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        CategoriesService,
        {
          provide: DatabaseService,
          useValue: {
            query: jest.fn(),
          },
        },
      ],
    }).compile();

    service = module.get<CategoriesService>(CategoriesService);
    databaseService = module.get<DatabaseService>(DatabaseService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('findByMenuId', () => {
    it('should return categories for a valid menu', async () => {
      // Arrange
      jest
        .spyOn(databaseService, 'query')
        .mockResolvedValueOnce({ rows: [{ id: mockMenuId }] }); // menu exists check
      jest
        .spyOn(databaseService, 'query')
        .mockResolvedValueOnce({ rows: [mockCategory] }); // categories query

      // Act
      const result = await service.findByMenuId(mockMenuId);

      // Assert
      expect(result).toEqual([mockCategory]);
      expect(databaseService.query).toHaveBeenCalledTimes(2);
    });

    it('should throw NotFoundException when menu does not exist', async () => {
      // Arrange
      jest.spyOn(databaseService, 'query').mockResolvedValueOnce({ rows: [] }); // menu not found

      // Act & Assert
      await expect(service.findByMenuId(mockMenuId)).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('findById', () => {
    it('should return a category by id', async () => {
      // Arrange
      jest
        .spyOn(databaseService, 'query')
        .mockResolvedValueOnce({ rows: [mockCategory] });

      // Act
      const result = await service.findById('cat-entradas-1');

      // Assert
      expect(result).toEqual(mockCategory);
      expect(databaseService.query).toHaveBeenCalledWith(expect.any(String), [
        'cat-entradas-1',
      ]);
    });

    it('should throw NotFoundException when category not found', async () => {
      // Arrange
      jest.spyOn(databaseService, 'query').mockResolvedValueOnce({ rows: [] });

      // Act & Assert
      await expect(service.findById('non-existent-id')).rejects.toThrow(
        NotFoundException,
      );
    });
  });
});
