import { NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { CategoriesController } from './categories.controller';
import { CategoriesService } from './categories.service';
import { CategoryResponseDto } from './dto';

describe('CategoriesController', () => {
  let controller: CategoriesController;
  let service: CategoriesService;

  const mockCategory: CategoryResponseDto = {
    id: 'cat-entradas-1',
    restaurant_id: 'res-uuid-1',
    menu_id: 'menu-uuid-1',
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
      controllers: [CategoriesController],
      providers: [
        {
          provide: CategoriesService,
          useValue: {
            findByMenuId: jest.fn(),
            findById: jest.fn(),
          },
        },
      ],
    }).compile();

    controller = module.get<CategoriesController>(CategoriesController);
    service = module.get<CategoriesService>(CategoriesService);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('findByMenuId', () => {
    it('should return categories for a menu', async () => {
      // Arrange
      const menuId = 'menu-uuid-1';
      jest.spyOn(service, 'findByMenuId').mockResolvedValue([mockCategory]);

      // Act
      const result = await controller.findByMenuId(menuId);

      // Assert
      expect(result.success).toBe(true);
      expect(result.data).toEqual([mockCategory]);
      expect(service.findByMenuId).toHaveBeenCalledWith(menuId);
    });
  });

  describe('findById', () => {
    it('should return a category by id', async () => {
      // Arrange
      const categoryId = 'cat-entradas-1';
      jest.spyOn(service, 'findById').mockResolvedValue(mockCategory);

      // Act
      const result = await controller.findById(categoryId);

      // Assert
      expect(result.success).toBe(true);
      expect(result.data).toEqual(mockCategory);
      expect(service.findById).toHaveBeenCalledWith(categoryId);
    });

    it('should throw NotFoundException when category not found', async () => {
      // Arrange
      const categoryId = 'non-existent-id';
      jest
        .spyOn(service, 'findById')
        .mockRejectedValue(new NotFoundException());

      // Act & Assert
      await expect(controller.findById(categoryId)).rejects.toThrow(
        NotFoundException,
      );
    });
  });
});
